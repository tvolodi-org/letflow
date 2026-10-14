defmodule Letflow.Api.TokenView do
  @moduledoc """
  The metadata-only response map of an API token (REQ-076 §6.2, GH 2552; moved verbatim
  out of `Letflow.Routers.Identity` by REQ-497 PR 1b, design
  `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` section 7.2, so that
  `GET /identity/tokens`, `DELETE /identity/tokens/:id` and
  `GET /tenant/scope-enforcement/token-preconditions` share one shape).

  Exactly the keys `id`, `name`, `user_id`, `issuer_user_id`, `roles`, `status`,
  `created_at`, `expires_at`, `revoked_at`, `last_used_at`. It structurally excludes
  `token_hash` and has no parameter through which a plaintext could reach it (INV-4).
  """

  alias Letflow.Identity.ApiToken

  @doc """
  The token map. `status` is the effective status from
  `Letflow.Identity.token_effective_status/3` (revoked > expired > owner_inactive >
  active), rendered lowercase; `issuer_user_id` is always present (null for a legacy row).
  """
  @spec token_map(ApiToken.t(), :revoked | :expired | :owner_inactive | :active) :: map()
  def token_map(%ApiToken{} = token, status) do
    %{
      "id" => token.id,
      "name" => token.name,
      "user_id" => token.user_id,
      "issuer_user_id" => token.issuer_user_id,
      "roles" => token.roles,
      "status" => Atom.to_string(status),
      "created_at" => iso8601(token.inserted_at),
      "expires_at" => iso8601_or_nil(token.expires_at),
      "revoked_at" => iso8601_or_nil(token.revoked_at),
      "last_used_at" => iso8601_or_nil(token.last_used_at)
    }
  end

  defp iso8601_or_nil(nil), do: nil
  defp iso8601_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # `inserted_at` is a NaiveDateTime treated as UTC (the router's own convention).
  defp iso8601(%NaiveDateTime{} = naive),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
end
