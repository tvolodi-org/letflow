defmodule Letflow.Oidc.ClaimMapping do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Pure mapping from verified OIDC claims to a `Letflow.Oidc.IdentityContext`.
  Ported from `src/oidc/claim_mapping.zig`'s `mapVerifiedClaims` (the pure,
  no-I/O function — Zig's `MappingError`, not `loadClaimMappingConfig`'s
  I/O-performing `ClaimMappingError`; see below).

  ## Input shape differs from Zig by necessity, not by choice

  Zig's `mapVerifiedClaims` takes `subject: []const u8` and
  `raw_claims_json: []const u8` (a JSON **string** it parses itself via
  `std.json.parseFromSlice`) — parsing a string is computation, not I/O, so
  this stays inside Zig's "pure function" boundary. `ueberauth_oidcc`'s
  callback already hands back claims as an already-parsed, string-keyed map
  (confirmed against `deps/ueberauth_oidcc/lib/ueberauth_oidcc/raw_info.ex`'s
  `string_map()` type), so `map_verified_claims/3` takes `claims` as a map
  directly — there is no re-parse step, and no JSON-parse-error case exists
  in this port.

  ## Error set is narrower than Zig's, deliberately

  Zig's `MappingError` has four members (`SubClaimMissing`,
  `ClaimPathMalformed`, `ClaimTypeMismatch`, `OutOfMemory`). Only
  `SubClaimMissing` has a reachable Elixir equivalent:

    * `ClaimPathMalformed`/`ClaimTypeMismatch` exist to cover JSON-parse-time
      and path-resolution-time failures specific to walking a freshly-parsed
      `std.json.Value` tree — since this port takes an already-map-shaped
      `claims` argument and `resolve_claim_path/2` never raises (it returns
      `nil` on any resolution failure, matching Zig's own
      `resolveJsonPath`/`orelse return null` behavior), neither case can
      occur here.
    * `OutOfMemory` has no BEAM-side counterpart — an actual OOM condition
      kills the process/node, which is not a case any Elixir `@spec` models.

  This module also does not port `loadClaimMappingConfig` or
  `ClaimMappingError` (config loaded from a DB-backed `realm_claim_mapping_config`
  table) — REQ-017's own scope explicitly excludes a DB-backed per-realm
  config table; see `Letflow.Oidc.ClaimMappingConfig` for the
  application-config-sourced equivalent used instead.

  See `lib/letflow/design/req017-claim-mapping.md` for the full design
  (§1-§3 cover the above in detail; §9 gives the zero-I/O call-graph
  enumeration this module's structure follows).

  ## Zero I/O

  `map_verified_claims/3` and every function in its call graph
  (`resolve_claim_path/2`, `resolve_optional_string_claim/3`,
  `resolve_roles/2`) take only in-memory arguments and return only computed
  values: no `Letflow.Repo` call, no HTTP client call, no `File`/`:file`
  call, no `GenServer.call`, no `Application.get_env`/`Application.fetch_env!`
  anywhere in this subtree. Config resolution
  (`Letflow.Oidc.ClaimMappingConfig.for_realm/1`) happens one level above, in
  the caller — this function always takes an already-resolved
  `ClaimMappingConfig` struct as its first argument.
  """

  alias Letflow.Oidc.ClaimMappingConfig
  alias Letflow.Oidc.IdentityContext

  @type mapping_error :: :sub_claim_missing

  @doc """
  Maps verified OIDC claims to an `IdentityContext`, using `config` to
  determine which claim path supplies each field.

  Returns `{:error, :sub_claim_missing}` when `subject` is `""` or `nil` —
  matching Zig's `if (subject.len == 0) return error.SubClaimMissing` check,
  generalized to also treat `nil` as "no usable subject value" (Zig's
  `subject` parameter is non-optional, so this is this port's own extension
  beyond the literal source; see design doc §7.3 OQ-2).

  PROVENANCE (historical, not current decision authority):
  Every other field defaults per `claim_mapping.zig`'s Key Invariant 3
  (missing claim, or claim present but the wrong JSON type, both converge on
  the same default — never an error): `email` -> `""`, `preferred_username`
  -> the `subject` value, `roles` -> `[]`, `display_name` -> `nil`,
  `tenant_id` -> `nil`.
  """
  @spec map_verified_claims(
          config :: ClaimMappingConfig.t(),
          subject :: String.t() | nil,
          claims :: %{optional(String.t()) => term()}
        ) :: {:ok, IdentityContext.t()} | {:error, mapping_error()}
  def map_verified_claims(%ClaimMappingConfig{} = config, subject, claims)
      when (is_binary(subject) or is_nil(subject)) and is_map(claims) do
    if subject in [nil, ""] do
      {:error, :sub_claim_missing}
    else
      {:ok,
       %IdentityContext{
         external_user_id: subject,
         tenant_id: resolve_optional_string_claim(claims, config.tenant_id_claim, nil),
         realm: config.realm,
         roles: resolve_roles(claims, config.roles_claim_paths),
         email: resolve_optional_string_claim(claims, config.email_claim, ""),
         preferred_username:
           resolve_optional_string_claim(claims, config.preferred_username_claim, subject),
         display_name: resolve_optional_string_claim(claims, config.display_name_claim, nil),
         # ISS-1030: strict equality with the JSON boolean `true`; the string
         # "true", 1, a missing claim and any other value are all `false`.
         # The claim name is fixed, not configurable.
         email_verified: Map.get(claims, "email_verified") == true
       }}
    end
  end

  @doc """
  Walks `claims` along `path` (a dot-delimited string, e.g. `"realm_access.roles"`),
  returning the resolved value or `nil`. Elixir port of `resolveJsonPath` +
  `splitPath` combined (folded into one function since Elixir has no
  separate allocate-then-free step to justify keeping them apart the way
  Zig's manual-memory-management style does).

  Any segment whose current value is not a map, or whose key is absent,
  returns `nil` immediately — never raises.
  """
  @spec resolve_claim_path(claims :: %{optional(String.t()) => term()}, path :: String.t()) ::
          term() | nil
  def resolve_claim_path(claims, path) when is_map(claims) and is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce(claims, fn
      _segment, nil ->
        nil

      segment, current when is_map(current) ->
        Map.get(current, segment)

      _segment, _current ->
        nil
    end)
  end

  @doc """
  PROVENANCE (historical, not current decision authority):
  Shared helper for the `email`/`preferred_username`/`display_name`/`tenant_id`
  fields (`claim_mapping.zig`'s structurally-identical "missing-or-wrong-type
  both default identically" rule, confirmed across all four call sites in the
  source): resolves `path` via `resolve_claim_path/2`; if the result is a
  binary, returns it; otherwise (`nil`, or present-but-wrong-type — number,
  map, list, boolean) returns `default` unchanged.
  """
  @spec resolve_optional_string_claim(
          claims :: %{optional(String.t()) => term()},
          path :: String.t(),
          default :: String.t() | nil
        ) :: String.t() | nil
  def resolve_optional_string_claim(claims, path, default) do
    case resolve_claim_path(claims, path) do
      value when is_binary(value) -> value
      _other -> default
    end
  end

  @doc """
  Resolves the `roles` field: iterates `paths` in order, and for the first
  path whose resolved value is a list, maps each element to itself if it's a
  binary, else `""` (matching Zig's `switch (item) { .string => |s| s, else
  => "" }` — non-string array elements become empty strings, not dropped,
  preserving array length), returning that list immediately (short-circuit
  on first list-typed match). If no path resolves to a list, returns `[]`.
  """
  @spec resolve_roles(
          claims :: %{optional(String.t()) => term()},
          paths :: [String.t()]
        ) :: [String.t()]
  def resolve_roles(claims, paths) do
    Enum.find_value(paths, [], fn path ->
      case resolve_claim_path(claims, path) do
        value when is_list(value) ->
          Enum.map(value, fn
            item when is_binary(item) -> item
            _other -> ""
          end)

        _other ->
          nil
      end
    end)
  end
end
